const mongoose = require('mongoose');

const HeartbeatSchema = new mongoose.Schema({
  ea_name:    { type: String, required: true },
  symbol:     { type: String, required: true },
  timeframe:  { type: String, default: 'M15' },
  account_id: { type: String, default: '' },
  balance:    { type: Number, default: 0 },
  equity:     { type: Number, default: 0 },
  message:    { type: String, default: '' },
}, { timestamps: true });

// Auto-expire heartbeats after 24 hours
HeartbeatSchema.index({ createdAt: 1 }, { expireAfterSeconds: 86400 });

module.exports = mongoose.model('Heartbeat', HeartbeatSchema);
