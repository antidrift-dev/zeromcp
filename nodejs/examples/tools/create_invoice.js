export default {
  description: "Create an invoice",
  input: {
    customer_id: 'string',
    amount: 'number',
  },
  execute: async ({ customer_id, amount }) => {
    // Simulated — replace with real Stripe call
    return {
      id: `inv_${Date.now()}`,
      customer_id,
      amount,
      status: 'draft',
      created: new Date().toISOString(),
    };
  },
};
