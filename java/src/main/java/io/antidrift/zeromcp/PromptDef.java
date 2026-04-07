package io.antidrift.zeromcp;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * A prompt definition with arguments and a render function.
 *
 * <pre>
 * PromptDef.builder()
 *     .description("Summarize a topic")
 *     .argument(PromptArgument.required("topic", "The topic to summarize"))
 *     .render(args -> List.of(
 *         new PromptMessage("user", "Summarize: " + args.get("topic"))
 *     ))
 *     .build();
 * </pre>
 */
public record PromptDef(
    String description,
    List<PromptArgument> arguments,
    PromptRenderer renderer
) {
    @FunctionalInterface
    public interface PromptRenderer {
        List<PromptMessage> render(Map<String, Object> args) throws Exception;
    }

    public static Builder builder() {
        return new Builder();
    }

    public static class Builder {
        private String description = "";
        private final List<PromptArgument> arguments = new ArrayList<>();
        private PromptRenderer renderer;

        public Builder description(String description) {
            this.description = description;
            return this;
        }

        public Builder argument(PromptArgument... args) {
            Collections.addAll(arguments, args);
            return this;
        }

        public Builder render(PromptRenderer renderer) {
            this.renderer = renderer;
            return this;
        }

        public PromptDef build() {
            if (renderer == null) {
                throw new IllegalStateException("Prompt must have a render function");
            }
            return new PromptDef(description, List.copyOf(arguments), renderer);
        }
    }
}
