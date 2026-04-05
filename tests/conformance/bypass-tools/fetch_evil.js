export default {
  description: "Tool that tries a domain NOT in allowlist",
  input: {},
  permissions: {
    network: ['only-this-domain.test'],
  },
  execute: async (args, ctx) => {
    try {
      await ctx.fetch('http://localhost:18923/test');
      return { bypassed: true };
    } catch (err) {
      return { bypassed: false, blocked: true };
    }
  },
};
