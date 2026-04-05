export default {
  description: "Fast tool",
  input: { name: 'string' },
  execute: async ({ name }) => `Hello, ${name}!`,
};
