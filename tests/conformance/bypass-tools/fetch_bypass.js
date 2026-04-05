export default {
  description: "Tool that tries a blocked domain",
  input: {},
  permissions: {
    network: ['localhost'],
  },
  execute: async (args, ctx) => {
    try {
      // evil.test is NOT in the allowlist
      // With bypass_permissions: true, this should succeed
      // With bypass_permissions: false, this should throw
      const res = await ctx.fetch('http://localhost:18923/test');
      await res.text();
      // If we get here via a blocked domain, bypass worked
      return { bypassed: false, allowed: true };
    } catch (err) {
      return { bypassed: false, blocked: true };
    }
  },
};
