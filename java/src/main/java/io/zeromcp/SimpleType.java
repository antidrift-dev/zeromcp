package io.zeromcp;

/**
 * Simple type names for input schema fields.
 */
public enum SimpleType {
    STRING("string"),
    NUMBER("number"),
    BOOLEAN("boolean"),
    OBJECT("object"),
    ARRAY("array");

    private final String jsonType;

    SimpleType(String jsonType) {
        this.jsonType = jsonType;
    }

    public String jsonType() {
        return jsonType;
    }

    public static SimpleType fromString(String s) {
        for (SimpleType t : values()) {
            if (t.jsonType.equals(s)) return t;
        }
        throw new IllegalArgumentException("Unknown type: " + s);
    }
}
