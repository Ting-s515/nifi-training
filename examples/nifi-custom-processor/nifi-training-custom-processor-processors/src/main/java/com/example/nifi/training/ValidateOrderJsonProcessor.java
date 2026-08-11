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

@Tags({"training", "json", "record", "validation"})
@CapabilityDescription("Validates required fields in one JSON order record and routes the FlowFile by validation result.")
@InputRequirement(InputRequirement.Requirement.INPUT_REQUIRED)
@WritesAttributes({
        @WritesAttribute(attribute = "training.validation.status", description = "The validation status: valid, invalid, or error."),
        @WritesAttribute(attribute = "training.validation.reason", description = "The accepted result or semicolon-separated validation reason codes.")
})
public class ValidateOrderJsonProcessor extends AbstractProcessor {

    public static final String ORDER_ID_FIELD = "order_id";
    public static final String CUSTOMER_FIELD = "customer";
    public static final String AMOUNT_FIELD = "amount";
    public static final String STATUS_ATTRIBUTE = "training.validation.status";
    public static final String REASON_ATTRIBUTE = "training.validation.reason";

    public static final PropertyDescriptor RECORD_READER = new PropertyDescriptor.Builder()
            .name("Record Reader")
            .displayName("Record Reader")
            .description("The Controller Service used to parse the JSON FlowFile into a Record.")
            .required(true)
            .identifiesControllerService(RecordReaderFactory.class)
            .build();

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
        // NiFi reads these collections during initialization to expose the component contract before scheduling it.
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
        FlowFile flowFile = session.get();
        if (flowFile == null) {
            // An empty input queue is a normal scheduling result and does not represent a validation failure.
            return;
        }

        ValidationResult result;
        try {
            result = validateOrder(context, session, flowFile);
        } catch (final IOException | MalformedRecordException | SchemaNotFoundException exception) {
            getLogger().error("Unable to read the JSON order record", exception);
            result = ValidationResult.error("record-reader.error");
        }

        flowFile = session.putAllAttributes(flowFile, Map.of(
                STATUS_ATTRIBUTE, result.status(),
                REASON_ATTRIBUTE, result.reason()));

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
        final RecordReaderFactory readerFactory = context.getProperty(RECORD_READER)
                .asControllerService(RecordReaderFactory.class);

        try (InputStream input = session.read(flowFile);
             RecordReader reader = readerFactory.createRecordReader(flowFile, input, getLogger())) {
            final Record record = reader.nextRecord();
            if (record == null) {
                return ValidationResult.invalid("record.required");
            }

            final List<String> errors = collectValidationErrors(record);
            if (reader.nextRecord() != null) {
                errors.add("record.count");
            }
            if (!errors.isEmpty()) {
                return ValidationResult.invalid(String.join(";", errors));
            }
            return ValidationResult.accepted();
        }
    }

    private List<String> collectValidationErrors(final Record record) {
        final List<String> errors = new ArrayList<>();
        validateTextField(record, ORDER_ID_FIELD, errors);
        validateTextField(record, CUSTOMER_FIELD, errors);
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
