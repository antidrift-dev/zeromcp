package io.antidrift.zeromcp;

/**
 * A message returned from a prompt render function.
 *
 * @param role "user" or "assistant"
 * @param text the message text content
 */
public record PromptMessage(String role, String text) {}
