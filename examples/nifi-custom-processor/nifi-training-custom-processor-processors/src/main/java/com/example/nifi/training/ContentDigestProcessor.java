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
import java.util.HexFormat;
import java.util.List;
import java.util.Set;

import org.apache.nifi.annotation.behavior.InputRequirement;
import org.apache.nifi.annotation.behavior.WritesAttribute;
import org.apache.nifi.annotation.behavior.WritesAttributes;
import org.apache.nifi.annotation.documentation.CapabilityDescription;
import org.apache.nifi.annotation.documentation.Tags;
import org.apache.nifi.components.AllowableValue;
import org.apache.nifi.components.PropertyDescriptor;
import org.apache.nifi.flowfile.FlowFile;
import org.apache.nifi.processor.AbstractProcessor;
import org.apache.nifi.processor.ProcessContext;
import org.apache.nifi.processor.ProcessSession;
import org.apache.nifi.processor.ProcessorInitializationContext;
import org.apache.nifi.processor.Relationship;
import org.apache.nifi.processor.exception.ProcessException;
import org.apache.nifi.processor.util.StandardValidators;

@Tags({"training", "content", "digest"})
@CapabilityDescription("Calculates a digest for FlowFile content and writes it to a FlowFile attribute.")
@InputRequirement(InputRequirement.Requirement.INPUT_REQUIRED)
@WritesAttributes({
        @WritesAttribute(attribute = "content.digest", description = "The digest value written by default."),
        @WritesAttribute(attribute = "content.digest.failure.reason", description = "The exception type when digest calculation fails.")
})
// These annotations define the runtime contract that NiFi validates and exposes before execution.
public class ContentDigestProcessor extends AbstractProcessor {

    // Restrict the algorithms at the property boundary so unsupported values fail validation before processing.
    public static final AllowableValue SHA_256 = new AllowableValue(
            "SHA-256", "SHA-256", "SHA-256 produces a 256-bit digest.");
    public static final AllowableValue SHA_512 = new AllowableValue(
            "SHA-512", "SHA-512", "SHA-512 produces a 512-bit digest.");

    public static final PropertyDescriptor HASH_ALGORITHM = new PropertyDescriptor.Builder()
            .name("Hash Algorithm")
            .displayName("Hash Algorithm")
            .description("The digest algorithm used to process the FlowFile content.")
            .required(true)
            .allowableValues(SHA_256, SHA_512)
            .defaultValue(SHA_256.getValue())
            .build();

    public static final PropertyDescriptor OUTPUT_ATTRIBUTE = new PropertyDescriptor.Builder()
            .name("Output Attribute")
            .displayName("Output Attribute")
            .description("The FlowFile attribute that receives the lowercase hexadecimal digest.")
            .required(true)
            .defaultValue("content.digest")
            .addValidator(StandardValidators.NON_EMPTY_VALIDATOR)
            .build();

    // Keep both outcomes routable so a flow can handle successful and failed processing explicitly.
    public static final Relationship REL_SUCCESS = new Relationship.Builder()
            .name("success")
            .description("FlowFiles whose content was hashed successfully.")
            .build();

    public static final Relationship REL_FAILURE = new Relationship.Builder()
            .name("failure")
            .description("FlowFiles whose content could not be hashed.")
            .build();

    public static final String FAILURE_REASON_ATTRIBUTE = "content.digest.failure.reason";

    private List<PropertyDescriptor> descriptors;
    private Set<Relationship> relationships;

    @Override
    protected void init(final ProcessorInitializationContext context) {
        // NiFi reads these collections during initialization to build the component contract before scheduling it.
        descriptors = List.of(HASH_ALGORITHM, OUTPUT_ATTRIBUTE);
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
            // An invocation can find an empty input queue, so there is no FlowFile to process or transfer.
            return;
        }

        final String algorithm = context.getProperty(HASH_ALGORITHM).getValue();
        final String outputAttribute = context.getProperty(OUTPUT_ATTRIBUTE).getValue();

        try {
            final MessageDigest messageDigest = createMessageDigest(algorithm);
            // Process content through NiFi's session in chunks to keep memory usage bounded for large FlowFiles.
            session.read(flowFile, input -> {
                final byte[] buffer = new byte[8192];
                int bytesRead;
                while ((bytesRead = input.read(buffer)) >= 0) {
                    if (bytesRead > 0) {
                        messageDigest.update(buffer, 0, bytesRead);
                    }
                }
            });

            final String digest = HexFormat.of().formatHex(messageDigest.digest());
            // Store the result as metadata and retain the original content for downstream processors.
            flowFile = session.putAttribute(flowFile, outputAttribute, digest);
            session.transfer(flowFile, REL_SUCCESS);
        } catch (final NoSuchAlgorithmException exception) {
            getLogger().error("Unable to calculate the FlowFile content digest", exception);
            // Penalize the FlowFile to avoid immediate repeated failures when the cause is retryable.
            session.penalize(flowFile);
            // Preserve a machine-readable reason so failure handling does not need to parse logs.
            flowFile = session.putAttribute(flowFile, FAILURE_REASON_ATTRIBUTE,
                    exception.getClass().getSimpleName());
            session.transfer(flowFile, REL_FAILURE);
        }
    }

    // Keep the digest factory overridable so tests can exercise failure routing without changing runtime behavior.
    protected MessageDigest createMessageDigest(final String algorithm) throws NoSuchAlgorithmException {
        return MessageDigest.getInstance(algorithm);
    }
}
