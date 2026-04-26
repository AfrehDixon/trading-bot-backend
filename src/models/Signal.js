const mongoose = require('mongoose');

const SignalSchema = new mongoose.Schema({
  ea_name:   { type: String, required: true },
  symbol:    { type: String, required: true },
  direction: { type: String, required: true },
  score:     { type: Number, default: 0 },
  pattern:   { type: String, default: '' },
  reason:    { type: String, default: '' },
  entry:     { type: Number, default: 0 },
  sl:        { type: Number, default: 0 },
  tp:        { type: Number, default: 0 },
  rr:        { type: Number, default: 0 },
  acted:     { type: Boolean, default: false },
}, { timestamps: true });

SignalSchema.index({ ea_name: 1, createdAt: -1 });

module.exports = mongoose.model('Signal', SignalSchema);
