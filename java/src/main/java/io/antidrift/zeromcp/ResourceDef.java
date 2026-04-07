package io.antidrift.zeromcp;

import java.util.function.Supplier;

/**
 * A static resource definition.
 *
 * <pre>
 * ResourceDef.builder()
 *     .uri("config://app/settings")
 *     .description("Application settings")
 *     .mimeType("application/json")
 *     .read(() -> "{\"theme\":\"dark\"}")
 *     .build();
 * </pre>
 */
public record ResourceDef(
    String uri,
    String description,
    String mimeType,
    ResourceReader reader
) {
    @FunctionalInterface
    public interface ResourceReader {
        String read() throws Exception;
    }

    public static Builder builder() {
        return new Builder();
    }

    public static class Builder {
        private String uri = "";
        private String description = "";
        private String mimeType = "text/plain";
        private ResourceReader reader;

        public Builder uri(String uri) {
            this.uri = uri;
            return this;
        }

        public Builder description(String description) {
            this.description = description;
            return this;
        }

        public Builder mimeType(String mimeType) {
            this.mimeType = mimeType;
            return this;
        }

        public Builder read(ResourceReader reader) {
            this.reader = reader;
            return this;
        }

        public ResourceDef build() {
            if (reader == null) {
                throw new IllegalStateException("Resource must have a read function");
            }
            return new ResourceDef(uri, description, mimeType, reader);
        }
    }
}
