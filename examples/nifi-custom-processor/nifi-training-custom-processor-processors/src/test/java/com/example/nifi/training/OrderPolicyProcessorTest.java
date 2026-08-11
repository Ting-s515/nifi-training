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

class OrderPolicyProcessorTest {

    private static final String ORDER_SCHEMA = """
            {
              "type": "record",
              "name": "TrainingOrderPolicy",
              "fields": [
                {"name": "order_id", "type": ["null", "string"], "default": null},
                {"name": "customer", "type": ["null", "string"], "default": null},
                {"name": "customer_tier", "type": ["null", "string"], "default": null},
                {"name": "amount", "type": ["null", "double"], "default": null}
              ]
            }
            """;

    @Test
    void approvesStandardCustomerBelowManualReviewThreshold() throws Exception {
        final TestRunner runner = newRunner();
        final String content = "{\"order_id\":\"1001\",\"customer\":\"Alice\",\"customer_tier\":\"standard\",\"amount\":800}";
        runner.enqueue(content);

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_APPROVED, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_APPROVED).get(0);
        flowFile.assertAttributeEquals(OrderPolicyProcessor.DECISION_ATTRIBUTE, "approved");
        flowFile.assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "accepted");
        flowFile.assertContentEquals(content);
    }

    @Test
    void approvesVipCustomerBelowRejectThreshold() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1002\",\"customer\":\"Bob\",\"customer_tier\":\"vip\",\"amount\":4500}");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_APPROVED, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_APPROVED).get(0);
        flowFile.assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "accepted");
    }

    @Test
    void routesStandardCustomerAboveManualReviewThresholdToManualReview() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1003\",\"customer\":\"Carol\",\"customer_tier\":\"standard\",\"amount\":1500}");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_MANUAL_REVIEW, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_MANUAL_REVIEW).get(0);
        flowFile.assertAttributeEquals(OrderPolicyProcessor.DECISION_ATTRIBUTE, "manual_review");
        flowFile.assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "tier.amount.review");
    }

    @Test
    void rejectsOrderAboveRejectThreshold() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1004\",\"customer\":\"Dora\",\"customer_tier\":\"vip\",\"amount\":6000}");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_REJECTED, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_REJECTED).get(0);
        flowFile.assertAttributeEquals(OrderPolicyProcessor.DECISION_ATTRIBUTE, "rejected");
        flowFile.assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "amount.limit");
    }

    @Test
    void usesConfiguredThresholds() throws Exception {
        final TestRunner runner = newRunner();
        runner.setProperty(OrderPolicyProcessor.MANUAL_REVIEW_THRESHOLD, "200");
        runner.setProperty(OrderPolicyProcessor.REJECT_THRESHOLD, "1000");
        runner.enqueue("{\"order_id\":\"1005\",\"customer\":\"Eve\",\"customer_tier\":\"standard\",\"amount\":250}");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_MANUAL_REVIEW, 1);
        runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_MANUAL_REVIEW).get(0)
                .assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "tier.amount.review");
    }

    @Test
    void rejectsThresholdConfigurationWhenRejectIsNotGreater() throws Exception {
        final TestRunner runner = newRunner();
        runner.setProperty(OrderPolicyProcessor.MANUAL_REVIEW_THRESHOLD, "1000");
        runner.setProperty(OrderPolicyProcessor.REJECT_THRESHOLD, "1000");

        assertFalse(runner.isValid());
    }

    @Test
    void routesMissingCustomerTierToFailure() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1006\",\"customer\":\"Frank\",\"amount\":100}");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(OrderPolicyProcessor.DECISION_ATTRIBUTE, "error");
        flowFile.assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "customer_tier.required");
    }

    @Test
    void routesMalformedJsonToFailure() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{invalid-json");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(OrderPolicyProcessor.DECISION_ATTRIBUTE, "error");
        flowFile.assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "record-reader.error");
    }

    @Test
    void rejectsMultipleRecordsInOneFlowFile() throws Exception {
        final TestRunner runner = newRunner();
        runner.enqueue("{\"order_id\":\"1001\",\"customer_tier\":\"standard\",\"amount\":100}\n"
                + "{\"order_id\":\"1002\",\"customer_tier\":\"standard\",\"amount\":200}");

        runner.run();

        runner.assertAllFlowFilesTransferred(OrderPolicyProcessor.REL_FAILURE, 1);
        runner.getFlowFilesForRelationship(OrderPolicyProcessor.REL_FAILURE).get(0)
                .assertAttributeEquals(OrderPolicyProcessor.REASON_ATTRIBUTE, "record.count");
    }

    @Test
    void isInvalidWithoutRecordReader() {
        final TestRunner runner = TestRunners.newTestRunner(new OrderPolicyProcessor());

        assertFalse(runner.isValid());
    }

    private TestRunner newRunner() throws Exception {
        final TestRunner runner = TestRunners.newTestRunner(new OrderPolicyProcessor());
        final JsonTreeReader reader = new JsonTreeReader();
        runner.addControllerService("json-reader", reader);
        runner.setProperty(reader, "Schema Access Strategy", "schema-text-property");
        runner.setProperty(reader, "Schema Text", ORDER_SCHEMA);
        runner.enableControllerService(reader);
        runner.setProperty(OrderPolicyProcessor.RECORD_READER, "json-reader");
        return runner;
    }
}
