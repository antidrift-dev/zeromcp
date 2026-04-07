export default {
  description: 'A dynamic resource',
  mimeType: 'application/json',
  read: async () => JSON.stringify({ dynamic: true }),
};
