package io.zeromcp;

/**
 * An input field definition — name, type, description, and whether it's optional.
 */
public record Input(String name, SimpleType type, String description, boolean optional) {

    public static Input required(String name, String type) {
        return new Input(name, SimpleType.fromString(type), null, false);
    }

    public static Input required(String name, String type, String description) {
        return new Input(name, SimpleType.fromString(type), description, false);
    }

    public static Input optional(String name, String type) {
        return new Input(name, SimpleType.fromString(type), null, true);
    }

    public static Input optional(String name, String type, String description) {
        return new Input(name, SimpleType.fromString(type), description, true);
    }
}
