/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.example.nifi.training;

import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.apache.nifi.annotation.behavior.InputRequirement;
import org.apache.nifi.annotation.behavior.WritesAttribute;
import org.apache.nifi.annotation.behavior.WritesAttributes;
import org.apache.nifi.annotation.documentation.CapabilityDescription;
import org.apache.nifi.annotation.documentation.Tags;
import org.apache.nifi.components.PropertyDescriptor;
import org.apache.nifi.components.ValidationContext;
import org.apache.nifi.components.ValidationResult;
import org.apache.nifi.flowfile.FlowFile;
import org.apache.nifi.processor.AbstractProcessor;
import org.apache.nifi.processor.ProcessContext;
import org.apache.nifi.processor.ProcessSession;
import org.apache.nifi.processor.ProcessorInitializationContext;
import org.apache.nifi.processor.Relationship;
import org.apache.nifi.processor.exception.ProcessException;
import org.apache.nifi.processor.util.StandardValidators;
import org.apache.nifi.schema.access.SchemaNotFoundException;
import org.apache.nifi.serialization.MalformedRecordException;
import org.apache.nifi.serialization.RecordReader;
import org.apache.nifi.serialization.RecordReaderFactory;
import org.apache.nifi.serialization.record.Record;

/**
 * Why：NiFi 內建元件無法直接表達 customer tier 與 amount 的跨欄位公司政策並輸出穩定
 * decision/reason code，因此以可配置門檻的客製化 Processor 集中決策與分流。
 */
@Tags({"training", "json", "record", "policy"})
@CapabilityDescription("Applies a configurable company order policy and routes each JSON order by its business decision.")
@InputRequirement(InputRequirement.Requirement.INPUT_REQUIRED)
@WritesAttributes({
        @WritesAttribute(attribute = "training.policy.decision", description = "The policy decision: approved, manual_review, rejected, or error."),
        @WritesAttribute(attribute = "training.policy.reason", description = "The stable policy decision or input error reason code.")
})
public class OrderPolicyProcessor extends AbstractProcessor {

    // 欄位與 attribute 名稱是 Processor 和下游 Flow 之間的穩定 contract，集中管理可避免分支使用不同字串。
    public static final String ORDER_ID_FIELD = "order_id";
    public static final String CUSTOMER_TIER_FIELD = "customer_tier";
    public static final String AMOUNT_FIELD = "amount";
    public static final String DECISION_ATTRIBUTE = "training.policy.decision";
    public static final String REASON_ATTRIBUTE = "training.policy.reason";

    // 由 Controller Service 負責格式解析，政策 Processor 因此只依賴 RecordReaderFactory 這個公開 API contract。
    public static final PropertyDescriptor RECORD_READER = new PropertyDescriptor.Builder()
            .name("Record Reader")
            .displayName("Record Reader")
            .description("The Controller Service used to parse the JSON FlowFile into a Record.")
            .required(true)
            .identifiesControllerService(RecordReaderFactory.class)
            .build();

    // 門檻設為 Processor properties，讓同一個 Java 元件能透過不同 Flow 設定不同公司的政策值。
    public static final PropertyDescriptor MANUAL_REVIEW_THRESHOLD = new PropertyDescriptor.Builder()
            .name("Manual Review Threshold")
            .displayName("Manual Review Threshold")
            .description("Orders above this amount require manual review when the customer is not VIP.")
            .required(true)
            .defaultValue("1000")
            .addValidator(StandardValidators.NUMBER_VALIDATOR)
            .build();

    public static final PropertyDescriptor REJECT_THRESHOLD = new PropertyDescriptor.Builder()
            .name("Reject Threshold")
            .displayName("Reject Threshold")
            .description("Orders above this amount are rejected regardless of customer tier.")
            .required(true)
            .defaultValue("5000")
            .addValidator(StandardValidators.NUMBER_VALIDATOR)
            .build();

    // VIP tier 也是設定值而非硬編碼，避免公司定義改名時必須重新編譯 Processor。
    public static final PropertyDescriptor VIP_CUSTOMER_TIER = new PropertyDescriptor.Builder()
            .name("VIP Customer Tier")
            .displayName("VIP Customer Tier")
            .description("The customer_tier value that can bypass the manual review threshold.")
            .required(true)
            .defaultValue("vip")
            .addValidator(StandardValidators.NON_BLANK_VALIDATOR)
            .build();

    // 每個政策結果使用獨立 relationship，讓下游可以分別接人工審核、拒絕、成功與錯誤處理流程。
    public static final Relationship REL_APPROVED = new Relationship.Builder()
            .name("approved")
            .description("Orders that pass the configured company policy.")
            .build();

    public static final Relationship REL_MANUAL_REVIEW = new Relationship.Builder()
            .name("manual-review")
            .description("Orders that require manual review before they can be accepted.")
            .build();

    public static final Relationship REL_REJECTED = new Relationship.Builder()
            .name("rejected")
            .description("Orders that exceed the configured rejection threshold.")
            .build();

    public static final Relationship REL_FAILURE = new Relationship.Builder()
            .name("failure")
            .description("FlowFiles with unreadable records or invalid policy input fields.")
            .build();

    private List<PropertyDescriptor> descriptors;
    private Set<Relationship> relationships;

    @Override
    protected void init(final ProcessorInitializationContext context) {
        // NiFi 會在排程前讀取這兩組 contract；初始化後不再變更可避免執行期間的設定漂移。
        descriptors = List.of(
                RECORD_READER,
                MANUAL_REVIEW_THRESHOLD,
                REJECT_THRESHOLD,
                VIP_CUSTOMER_TIER);
        relationships = Set.of(REL_APPROVED, REL_MANUAL_REVIEW, REL_REJECTED, REL_FAILURE);
    }

    @Override
    public Set<Relationship> getRelationships() {
        return relationships;
    }

    @Override
    public List<PropertyDescriptor> getSupportedPropertyDescriptors() {
        return descriptors;
    }

    @Override
    protected Collection<ValidationResult> customValidate(final ValidationContext context) {
        // 門檻之間的相對關係屬於設定 contract，提前在 UI validation 階段攔截，避免錯誤設定進入 runtime。
        final String manualThresholdText = context.getProperty(MANUAL_REVIEW_THRESHOLD).getValue();
        final String rejectThresholdText = context.getProperty(REJECT_THRESHOLD).getValue();
        if (manualThresholdText == null || rejectThresholdText == null) {
            return List.of();
        }

        try {
            final double manualThreshold = Double.parseDouble(manualThresholdText);
            final double rejectThreshold = Double.parseDouble(rejectThresholdText);
            if (!Double.isFinite(manualThreshold) || manualThreshold < 0
                    || !Double.isFinite(rejectThreshold) || rejectThreshold < 0) {
                return List.of(invalidConfiguration("Thresholds must be finite and non-negative."));
            }
            if (rejectThreshold <= manualThreshold) {
                return List.of(invalidConfiguration("Reject Threshold must be greater than Manual Review Threshold."));
            }
        } catch (NumberFormatException exception) {
            // 數字格式由 StandardValidators.NUMBER_VALIDATOR 回報，這裡只負責跨欄位關係的驗證。
            return List.of();
        }

        return List.of();
    }

    @Override
    public void onTrigger(final ProcessContext context, final ProcessSession session) throws ProcessException {
        FlowFile flowFile = session.get();
        if (flowFile == null) {
            // 空 queue 代表目前沒有工作，不應製造沒有來源的政策結果。
            return;
        }

        PolicyResult result;
        try {
            result = evaluatePolicy(context, session, flowFile);
        } catch (final IOException | MalformedRecordException | SchemaNotFoundException exception) {
            // Reader 或 schema 錯誤要保留在 failure path，讓下游能送往 dead-letter 或告警流程。
            getLogger().error("Unable to read the JSON order policy record", exception);
            result = PolicyResult.failure("record-reader.error");
        }

        // 用穩定 attributes 傳遞政策結果，讓下游不必解析 log 文字或重新讀取 JSON。
        flowFile = session.putAllAttributes(flowFile, Map.of(
                DECISION_ATTRIBUTE, result.decision(),
                REASON_ATTRIBUTE, result.reason()));
        session.transfer(flowFile, result.relationship());
    }

    private PolicyResult evaluatePolicy(
            final ProcessContext context,
            final ProcessSession session,
            final FlowFile flowFile
    ) throws IOException, MalformedRecordException, SchemaNotFoundException {
        // Processor 只依賴 RecordReaderFactory，格式解析責任由 Controller Service 承擔。
        final RecordReaderFactory readerFactory = context.getProperty(RECORD_READER)
                .asControllerService(RecordReaderFactory.class);
        // 從 ProcessContext 取得有效設定，讓 UI 或參數更新後的政策值能套用到後續 FlowFile。
        final double manualReviewThreshold = context.getProperty(MANUAL_REVIEW_THRESHOLD).asDouble();
        final double rejectThreshold = context.getProperty(REJECT_THRESHOLD).asDouble();
        final String vipCustomerTier = context.getProperty(VIP_CUSTOMER_TIER).getValue().trim();

        try (InputStream input = session.read(flowFile);
             RecordReader reader = readerFactory.createRecordReader(flowFile, input, getLogger())) {
            // 一個 FlowFile 代表一筆訂單，先確認第一筆存在，再檢查是否意外帶入多筆資料。
            final Record record = reader.nextRecord();
            if (record == null) {
                return PolicyResult.failure("record.required");
            }

            final List<String> errors = collectInputErrors(record);
            if (reader.nextRecord() != null) {
                // 一個 FlowFile 只代表一筆訂單，避免只處理第一筆造成資料靜默遺失。
                errors.add("record.count");
            }
            if (!errors.isEmpty()) {
                return PolicyResult.failure(String.join(";", errors));
            }

            final String customerTier = record.getAsString(CUSTOMER_TIER_FIELD).trim();
            final double amount = ((Number) record.getValue(AMOUNT_FIELD)).doubleValue();
            // 先判斷拒絕門檻，再判斷人工審核，確保高金額訂單不會被 VIP 條件繞過拒絕規則。
            if (amount > rejectThreshold) {
                return PolicyResult.rejected("amount.limit");
            }
            if (amount > manualReviewThreshold && !vipCustomerTier.equalsIgnoreCase(customerTier)) {
                return PolicyResult.manualReview("tier.amount.review");
            }
            return PolicyResult.approved();
        }
    }

    private List<String> collectInputErrors(final Record record) {
        // 固定錯誤順序讓 reason code 可預期，方便測試與下游告警規則穩定比對。
        final List<String> errors = new ArrayList<>();
        validateTextField(record, ORDER_ID_FIELD, errors);
        validateTextField(record, CUSTOMER_TIER_FIELD, errors);
        validateAmount(record, errors);
        return errors;
    }

    private void validateTextField(final Record record, final String fieldName, final List<String> errors) {
        final String value = record.getAsString(fieldName);
        if (value == null) {
            errors.add(fieldName + ".required");
        } else if (value.isBlank()) {
            errors.add(fieldName + ".blank");
        }
    }

    private void validateAmount(final Record record, final List<String> errors) {
        final Object value = record.getValue(AMOUNT_FIELD);
        if (value == null) {
            errors.add(AMOUNT_FIELD + ".required");
            return;
        }
        if (!(value instanceof Number number)) {
            errors.add(AMOUNT_FIELD + ".numeric");
            return;
        }

        final double amount = number.doubleValue();
        if (!Double.isFinite(amount)) {
            errors.add(AMOUNT_FIELD + ".numeric");
        } else if (amount <= 0) {
            errors.add(AMOUNT_FIELD + ".positive");
        }
    }

    private ValidationResult invalidConfiguration(final String explanation) {
        // 回傳 NiFi 可呈現在 Processor UI 的 invalid 結果，讓學員能從設定畫面直接找到原因。
        return new ValidationResult.Builder()
                .subject("Order policy thresholds")
                .valid(false)
                .explanation(explanation)
                .build();
    }

    // 將 attribute 值與 relationship 綁在同一個結果，避免分支更新其中一項後造成下游觀察與實際路由不一致。
    private record PolicyResult(String decision, String reason, Relationship relationship) {

        private static PolicyResult approved() {
            return new PolicyResult("approved", "accepted", REL_APPROVED);
        }

        private static PolicyResult manualReview(final String reason) {
            return new PolicyResult("manual_review", reason, REL_MANUAL_REVIEW);
        }

        private static PolicyResult rejected(final String reason) {
            return new PolicyResult("rejected", reason, REL_REJECTED);
        }

        private static PolicyResult failure(final String reason) {
            return new PolicyResult("error", reason, REL_FAILURE);
        }
    }
}
