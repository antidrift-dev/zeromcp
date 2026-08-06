export default {
  description: 'Greet someone by name',
  input: { name: 'string' },
  route: { method: 'GET', path: '/greet/:name' },
  execute: async ({ name }) => `Hello, ${name}!`,
};
