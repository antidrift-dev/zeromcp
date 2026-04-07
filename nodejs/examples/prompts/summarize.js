export default {
  description: "Summarize a piece of text",
  arguments: {
    text: 'string',
    style: { type: 'string', optional: true, description: 'brief or detailed' },
  },
  render: async ({ text, style }) => {
    const s = style || 'brief';
    return [
      { role: 'user', content: { type: 'text', text: `Summarize the following text in a ${s} style:\n\n${text}` } },
    ];
  },
};
