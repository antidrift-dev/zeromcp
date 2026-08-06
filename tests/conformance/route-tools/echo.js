export default {
  description: 'Echo a message',
  input: { message: 'string' },
  route: { method: 'POST', path: '/echo' },
  execute: async ({ message }) => ({ message, echoed: true }),
};
