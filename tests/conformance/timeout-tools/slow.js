export default {
  description: "Tool that takes 3 seconds",
  input: {},
  permissions: {
    execute_timeout: 2000,
  },
  execute: async () => {
    await new Promise(r => setTimeout(r, 3000));
    return { status: "ok" };
  },
};
