export default {
  description: 'Code review prompt',
  arguments: {
    code: 'string',
    language: { type: 'string', description: 'Programming language', optional: true },
  },
  render: async (args) => [
    { role: 'user', content: { type: 'text', text: `Review this ${args.language || 'code'}:\n${args.code}` } },
  ],
};
