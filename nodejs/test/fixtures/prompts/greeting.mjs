export default {
  description: 'Greet someone',
  arguments: {
    name: 'string',
  },
  render: async (args) => [
    { role: 'user', content: { type: 'text', text: `Hello, ${args.name}!` } },
  ],
};
