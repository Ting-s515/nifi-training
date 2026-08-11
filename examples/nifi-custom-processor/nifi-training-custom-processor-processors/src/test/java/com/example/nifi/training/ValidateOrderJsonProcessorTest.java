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

import org.apache.nifi.json.JsonTreeReader;
import org.apache.nifi.util.MockFlowFile;
import org.apache.nifi.util.TestRunner;
import org.apache.nifi.util.TestRunners;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ValidateOrderJsonProcessorTest {

    private static final String ORDER_SCHEMA = """
            {
              "type": "record",
              "name": "TrainingOrder",
              "fields": [
                {"name": "order_id", "type": ["null", "string"], "default": null},
                {"name": "customer", "type": ["null", "string"], "default": null},
                {"name": "amount", "type": ["null", "double"], "default": null}
              ]
            }
            """;

    @Test
    void routesValidOrderToSuccessAndPreservesContent() throws Exception {
        final TestRunner runner = newRunner();
        final String content = "{\"order_id\":\"1001\",\"customer\":\"Alice\",\"amount\":120.50}";
        runner.enqueue(content);

        runner.run();

        runner.assertAllFlowFilesTransferred(ValidateOrderJsonProcessor.REL_SUCCESS, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_SUCCESS).get(0);
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.STATUS_ATTRIBUTE, "valid");
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.REASON_ATTRIBUTE, "accepted");
        flowFile.assertContentEquals(content);
    }

    @Test
    void collectsAllBusinessValidationErrors() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\" \",\"amount\":0}");

        runner.run();

        runner.assertAllFlowFilesTransferred(ValidateOrderJsonProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.STATUS_ATTRIBUTE, "invalid");
        flowFile.assertAttributeEquals(
                ValidateOrderJsonProcessor.REASON_ATTRIBUTE,
                "order_id.blank;customer.required;amount.positive");
    }

    @Test
    void routesNonPositiveAmountToFailure() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1002\",\"customer\":\"Bob\",\"amount\":-1}");

        runner.run();

        runner.assertAllFlowFilesTransferred(ValidateOrderJsonProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.REASON_ATTRIBUTE, "amount.positive");
    }

    @Test
    void routesMalformedJsonToFailureWithReaderError() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{invalid-json");

        runner.run();

        runner.assertAllFlowFilesTransferred(ValidateOrderJsonProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.STATUS_ATTRIBUTE, "error");
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.REASON_ATTRIBUTE, "record-reader.error");
    }

    @Test
    void rejectsMultipleRecordsInOneFlowFile() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1001\",\"customer\":\"Alice\",\"amount\":120.50}\n"
                + "{\"order_id\":\"1002\",\"customer\":\"Bob\",\"amount\":80.00}");

        runner.run();

        runner.assertAllFlowFilesTransferred(ValidateOrderJsonProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(ValidateOrderJsonProcessor.REASON_ATTRIBUTE, "record.count");
    }

    @Test
    void doesNotTransferWithoutInput() throws Exception {
        final TestRunner runner = newRunner();

        runner.run();

        assertTrue(runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_SUCCESS).isEmpty());
        assertTrue(runner.getFlowFilesForRelationship(ValidateOrderJsonProcessor.REL_FAILURE).isEmpty());
    }

    @Test
    void isInvalidWithoutRecordReader() {
        final TestRunner runner = TestRunners.newTestRunner(new ValidateOrderJsonProcessor());

        assertFalse(runner.isValid());
    }

    private TestRunner newRunner() throws Exception {
        final TestRunner runner = TestRunners.newTestRunner(new ValidateOrderJsonProcessor());
        final JsonTreeReader reader = new JsonTreeReader();
        runner.addControllerService("json-reader", reader);
        runner.setProperty(reader, "Schema Access Strategy", "schema-text-property");
        runner.setProperty(reader, "Schema Text", ORDER_SCHEMA);
        runner.enableControllerService(reader);
        runner.setProperty(ValidateOrderJsonProcessor.RECORD_READER, "json-reader");
        return runner;
    }
}
