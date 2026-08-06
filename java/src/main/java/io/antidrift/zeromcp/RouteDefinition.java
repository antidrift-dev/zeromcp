package io.antidrift.zeromcp;

/** One route-annotated tool, as plain data. No HTTP routing/param-extraction is done here. */
public record RouteDefinition(String name, String method, String path, Tool tool) {}
