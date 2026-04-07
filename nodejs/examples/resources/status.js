export default {
  description: "Current server status",
  mimeType: "application/json",
  read: async () => {
    return JSON.stringify({
      uptime: process.uptime(),
      memory: Math.round(process.memoryUsage().heapUsed / 1024 / 1024) + 'MB',
      timestamp: new Date().toISOString(),
    });
  },
};
