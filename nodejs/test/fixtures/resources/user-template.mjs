export default {
  uriTemplate: 'resource:///users/{id}',
  description: 'User by ID',
  mimeType: 'application/json',
  read: async (params) => JSON.stringify({ userId: params.id }),
};
