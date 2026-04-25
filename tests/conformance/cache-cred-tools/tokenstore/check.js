export default {
  description: "Return the current token from credentials",
  input: {},
  execute: async (args, ctx) => ({ token: ctx.credentials?.token ?? null }),
};
