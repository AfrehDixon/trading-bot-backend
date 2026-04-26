const mongoose = require('mongoose');

const TradeSchema = new mongoose.Schema({
  ticket:      { type: Number, default: 0 },
  ea_name:     { type: String, required: true },
  symbol:      { type: String, required: true },
  direction:   { type: String, required: true, enum: ['BUY','SELL','buy','sell'] },
  lot_size:    { type: Number, default: 0 },
  entry_price: { type: Number, default: 0 },
  sl:          { type: Number, default: 0 },
  tp:          { type: Number, default: 0 },
  exit_price:  { type: Number, default: null },
  profit:      { type: Number, default: null },
  pips:        { type: Number, default: null },
  rr:          { type: Number, default: 0 },
  score:       { type: Number, default: 0 },
  reason:      { type: String, default: '' },
  status:      { type: String, default: 'open', enum: ['open','closed'] },
  closed_at:   { type: Date,   default: null },
}, { timestamps: true });

// Indexes for fast queries
TradeSchema.index({ ea_name: 1, status: 1 });
TradeSchema.index({ symbol: 1 });
TradeSchema.index({ createdAt: -1 });

module.exports = mongoose.model('Trade', TradeSchema);
