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
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.apache.nifi.annotation.behavior.InputRequirement;
import org.apache.nifi.annotation.behavior.WritesAttribute;
import org.apache.nifi.annotation.behavior.WritesAttributes;
import org.apache.nifi.annotation.documentation.CapabilityDescription;
import org.apache.nifi.annotation.documentation.Tags;
import org.apache.nifi.components.PropertyDescriptor;
import org.apache.nifi.flowfile.FlowFile;
import org.apache.nifi.processor.AbstractProcessor;
import org.apache.nifi.processor.ProcessContext;
import org.apache.nifi.processor.ProcessSession;
import org.apache.nifi.processor.ProcessorInitializationContext;
import org.apache.nifi.processor.Relationship;
import org.apache.nifi.processor.exception.ProcessException;
import org.apache.nifi.schema.access.SchemaNotFoundException;
import org.apache.nifi.serialization.MalformedRecordException;
import org.apache.nifi.serialization.RecordReader;
import org.apache.nifi.serialization.RecordReaderFactory;
import org.apache.nifi.serialization.record.Record;

/**
 * Why：NiFi 內建元件無法直接把訂單必要欄位、數值規則與穩定 reason code 組成同一個可部署
 * contract，因此以客製化 Processor 集中驗證並用 success/failure 交給下游處理。
 */
@Tags({"training", "json", "record", "validation"})
@CapabilityDescription("Validates required fields in one JSON order record and routes the FlowFile by validation result.")
@InputRequirement(InputRequirement.Requirement.INPUT_REQUIRED)
@WritesAttributes({
        @WritesAttribute(attribute = "training.validation.status", description = "The validation status: valid, invalid, or error."),
        @WritesAttribute(attribute = "training.validation.reason", description = "The accepted result or semicolon-separated validation reason codes.")
})
public class ValidateOrderJsonProcessor extends AbstractProcessor {

    // 將欄位名稱集中管理，避免 schema、驗證規則與 reason code 因為手寫字串不一致。
    public static final String ORDER_ID_FIELD = "order_id";
    public static final String CUSTOMER_FIELD = "customer";
    public static final String AMOUNT_FIELD = "amount";
    public static final String STATUS_ATTRIBUTE = "training.validation.status";
    public static final String REASON_ATTRIBUTE = "training.validation.reason";

    // 由 Controller Service 提供讀取能力，讓 Processor 能在不改 Java 邏輯的情況下替換 JSON、CSV 或 Avro reader。
    public static final PropertyDescriptor RECORD_READER = new PropertyDescriptor.Builder()
            .name("Record Reader")
            .displayName("Record Reader")
            .description("The Controller Service used to parse the JSON FlowFile into a Record.")
            .required(true)
            .identifiesControllerService(RecordReaderFactory.class)
            .build();

    // 使用明確 relationship 讓成功與失敗可以接到不同下游，保留資料流的可觀察性與後續處理選擇。
    public static final Relationship REL_SUCCESS = new Relationship.Builder()
            .name("success")
            .description("FlowFiles containing an order that passed all business validation rules.")
            .build();

    public static final Relationship REL_FAILURE = new Relationship.Builder()
            .name("failure")
            .description("FlowFiles containing malformed JSON or an order that failed business validation.")
            .build();

    private List<PropertyDescriptor> descriptors;
    private Set<Relationship> relationships;

    @Override
    protected void init(final ProcessorInitializationContext context) {
        // NiFi 會在排程前讀取這兩組 contract；在初始化時建立不可變集合，避免執行期間被意外修改。
        descriptors = List.of(RECORD_READER);
        relationships = Set.of(REL_SUCCESS, REL_FAILURE);
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
    public void onTrigger(final ProcessContext context, final ProcessSession session) throws ProcessException {
        // 每次排程只處理一個 FlowFile，讓 NiFi 的 session 與 retry 邊界對應到一筆訂單。
        FlowFile flowFile = session.get();
        if (flowFile == null) {
            // 空 queue 只是本次排程沒有資料，不應製造一個沒有來源的 failure FlowFile。
            return;
        }

        ValidationResult result;
        try {
            result = validateOrder(context, session, flowFile);
        } catch (final IOException | MalformedRecordException | SchemaNotFoundException exception) {
            // Reader 或 schema 錯誤仍屬於輸入處理結果；轉成穩定 reason code，讓下游可以記錄或送往 dead-letter。
            getLogger().error("Unable to read the JSON order record", exception);
            result = ValidationResult.error("record-reader.error");
        }

        // 將結果放在 FlowFile contract 中，讓下游只讀 attributes 就能分流或告警，不必解析 log 文字。
        flowFile = session.putAllAttributes(flowFile, Map.of(
                STATUS_ATTRIBUTE, result.status(),
                REASON_ATTRIBUTE, result.reason()));

        // 明確處理兩個 relationship，避免 validation 結果留在 session 中，也保留 failure 的可觀察性。
        if (result.valid()) {
            session.transfer(flowFile, REL_SUCCESS);
        } else {
            session.transfer(flowFile, REL_FAILURE);
        }
    }

    private ValidationResult validateOrder(
            final ProcessContext context,
            final ProcessSession session,
            final FlowFile flowFile
    ) throws IOException, MalformedRecordException, SchemaNotFoundException {
        // Processor 只依賴 RecordReaderFactory，格式與 schema 交由 Controller Service 配置，避免業務邏輯綁定 JSON library。
        final RecordReaderFactory readerFactory = context.getProperty(RECORD_READER)
                .asControllerService(RecordReaderFactory.class);

        try (InputStream input = session.read(flowFile);
             RecordReader reader = readerFactory.createRecordReader(flowFile, input, getLogger())) {
            // 同時關閉 FlowFile stream 與 reader，避免長時間或高併發處理時累積資源。
            final Record record = reader.nextRecord();
            if (record == null) {
                // 本課程定義一個 FlowFile 代表一筆訂單；沒有 record 時不能假設它是合法空訂單。
                return ValidationResult.invalid("record.required");
            }

            final List<String> errors = collectValidationErrors(record);
            if (reader.nextRecord() != null) {
                // 只驗證第一筆會靜默遺失同一 FlowFile 的其他訂單，因此明確拒絕多筆輸入。
                errors.add("record.count");
            }
            if (!errors.isEmpty()) {
                return ValidationResult.invalid(String.join(";", errors));
            }
            return ValidationResult.accepted();
        }
    }

    private List<String> collectValidationErrors(final Record record) {
        // 固定欄位驗證順序，讓 reason code 可預期，方便測試、告警與下游重試規則穩定比對。
        final List<String> errors = new ArrayList<>();
        validateTextField(record, ORDER_ID_FIELD, errors);
        validateTextField(record, CUSTOMER_FIELD, errors);
        validateAmount(record, errors);
        return errors;
    }

    private void validateTextField(final Record record, final String fieldName, final List<String> errors) {
        // 將缺少與空白分開，因為兩者通常需要不同的資料修正或告警處理。
        final String value = record.getAsString(fieldName);
        if (value == null) {
            errors.add(fieldName + ".required");
        } else if (value.isBlank()) {
            errors.add(fieldName + ".blank");
        }
    }

    private void validateAmount(final Record record, final List<String> errors) {
        // 先檢查原始型別，避免把 JSON 文字內容悄悄轉成金額而掩蓋上游 schema 問題。
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
            // NaN 不會小於等於零，若只檢查 amount <= 0 會讓非有限數值錯誤地通過。
            errors.add(AMOUNT_FIELD + ".numeric");
        } else if (amount <= 0) {
            errors.add(AMOUNT_FIELD + ".positive");
        }
    }

    // 將狀態、可讀原因與路由結果集中保存，避免 onTrigger 在不同錯誤分支重複組裝結果。
    private record ValidationResult(String status, String reason, boolean valid) {

        private static ValidationResult accepted() {
            return new ValidationResult("valid", "accepted", true);
        }

        private static ValidationResult invalid(final String reason) {
            return new ValidationResult("invalid", reason, false);
        }

        private static ValidationResult error(final String reason) {
            return new ValidationResult("error", reason, false);
        }
    }
}
