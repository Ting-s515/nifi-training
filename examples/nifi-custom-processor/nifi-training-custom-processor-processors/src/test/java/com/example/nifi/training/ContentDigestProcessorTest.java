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

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

import org.apache.nifi.util.MockFlowFile;
import org.apache.nifi.util.TestRunner;
import org.apache.nifi.util.TestRunners;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ContentDigestProcessorTest {

    @Test
    void routesFlowFileWithSha256DigestAndPreservesContent() {
        final TestRunner runner = TestRunners.newTestRunner(new ContentDigestProcessor());
        runner.enqueue("abc");

        runner.run();

        runner.assertAllFlowFilesTransferred(ContentDigestProcessor.REL_SUCCESS, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ContentDigestProcessor.REL_SUCCESS).get(0);
        flowFile.assertAttributeEquals(ContentDigestProcessor.OUTPUT_ATTRIBUTE.getDefaultValue(),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        flowFile.assertContentEquals("abc");
    }

    @Test
    void supportsSha512AndCustomOutputAttribute() {
        final TestRunner runner = TestRunners.newTestRunner(new ContentDigestProcessor());
        runner.setProperty(ContentDigestProcessor.HASH_ALGORITHM, ContentDigestProcessor.SHA_512.getValue());
        runner.setProperty(ContentDigestProcessor.OUTPUT_ATTRIBUTE, "training.digest");
        runner.enqueue("abc");

        runner.run();

        runner.assertAllFlowFilesTransferred(ContentDigestProcessor.REL_SUCCESS, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ContentDigestProcessor.REL_SUCCESS).get(0);
        flowFile.assertAttributeEquals("training.digest",
                "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
        flowFile.assertContentEquals("abc");
    }

    @Test
    void rejectsUnsupportedAlgorithm() {
        final TestRunner runner = TestRunners.newTestRunner(new ContentDigestProcessor());

        runner.setProperty(ContentDigestProcessor.HASH_ALGORITHM, "MD5");

        assertFalse(runner.isValid());
    }

    @Test
    void rejectsBlankOutputAttribute() {
        final TestRunner runner = TestRunners.newTestRunner(new ContentDigestProcessor());

        runner.setProperty(ContentDigestProcessor.OUTPUT_ATTRIBUTE, "");

        assertFalse(runner.isValid());
    }

    @Test
    void doesNotCreateTransferWhenThereIsNoInput() {
        final TestRunner runner = TestRunners.newTestRunner(new ContentDigestProcessor());

        runner.run();

        assertTrue(runner.getFlowFilesForRelationship(ContentDigestProcessor.REL_SUCCESS).isEmpty());
        assertTrue(runner.getFlowFilesForRelationship(ContentDigestProcessor.REL_FAILURE).isEmpty());
    }

    @Test
    void routesFailureAndKeepsFailureReasonOnFlowFile() {
        final ContentDigestProcessor processor = new ContentDigestProcessor() {
            @Override
            protected MessageDigest createMessageDigest(final String algorithm) throws NoSuchAlgorithmException {
                throw new NoSuchAlgorithmException("forced test failure");
            }
        };
        final TestRunner runner = TestRunners.newTestRunner(processor);
        runner.enqueue("abc");

        runner.run();

        runner.assertAllFlowFilesTransferred(ContentDigestProcessor.REL_FAILURE, 1);
        final MockFlowFile flowFile = runner.getFlowFilesForRelationship(ContentDigestProcessor.REL_FAILURE).get(0);
        flowFile.assertAttributeEquals(ContentDigestProcessor.FAILURE_REASON_ATTRIBUTE,
                NoSuchAlgorithmException.class.getSimpleName());
        flowFile.assertContentEquals("abc");
    }
}
