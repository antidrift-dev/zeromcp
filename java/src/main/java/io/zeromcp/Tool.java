package io.zeromcp;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * A tool definition built via the fluent builder API.
 *
 * Usage:
 * <pre>
 * Tool.builder()
 *     .description("Say hello")
 *     .input(Input.required("name", "string"))
 *     .execute((args, ctx) -> "Hello, " + args.get("name") + "!")
 *     .build();
 * </pre>
 */
public record Tool(
    String description,
    List<Input> inputs,
    Permissions permissions,
    ToolExecutor executor
) {
    public static Builder builder() {
        return new Builder();
    }

    public static class Builder {
        private String description = "";
        private final List<Input> inputs = new ArrayList<>();
        private Permissions permissions = Permissions.of();
        private ToolExecutor executor;

        public Builder description(String description) {
            this.description = description;
            return this;
        }

        public Builder input(Input... fields) {
            Collections.addAll(inputs, fields);
            return this;
        }

        public Builder permissions(Permissions permissions) {
            this.permissions = permissions;
            return this;
        }

        public Builder execute(ToolExecutor executor) {
            this.executor = executor;
            return this;
        }

        public Tool build() {
            if (executor == null) {
                throw new IllegalStateException("Tool must have an execute function");
            }
            return new Tool(description, List.copyOf(inputs), permissions, executor);
        }
    }
}
