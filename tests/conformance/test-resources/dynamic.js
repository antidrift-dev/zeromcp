export default {
  description: "Dynamic test resource",
  mimeType: "application/json",
  read: async () => JSON.stringify({ dynamic: true, timestamp: "test" }),
};
