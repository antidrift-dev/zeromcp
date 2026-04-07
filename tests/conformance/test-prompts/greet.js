export default {
  description: "Greeting prompt",
  arguments: {
    name: 'string',
    tone: { type: 'string', optional: true, description: 'formal or casual' },
  },
  render: async ({ name, tone }) => {
    const t = tone || 'casual';
    return [
      { role: 'user', content: { type: 'text', text: `Greet ${name} in a ${t} tone` } },
    ];
  },
};
