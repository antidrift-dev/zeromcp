export default {
  description: "Add two numbers together",
  input: {
    a: 'number',
    b: 'number',
  },
  execute: async ({ a, b }) => {
    return { sum: a + b };
  },
};
