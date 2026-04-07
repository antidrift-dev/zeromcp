package io.antidrift.zeromcp;

/**
 * An argument descriptor for a prompt.
 */
public record PromptArgument(String name, String description, boolean required) {

    public static PromptArgument required(String name, String description) {
        return new PromptArgument(name, description, true);
    }

    public static PromptArgument optional(String name, String description) {
        return new PromptArgument(name, description, false);
    }
}
