const express = require('express');
const router  = express.Router();
const Trade   = require('../models/Trade');

// POST /api/trading/trades/open
router.post('/open', async (req, res) => {
  const { ticket, ea_name, symbol, direction, lot_size, entry_price, sl, tp, rr, score, reason } = req.body;
  if (!ea_name || !symbol || !direction) return res.status(400).json({ error: 'ea_name, symbol, direction required' });
  try {
    const trade = await Trade.create({ ticket, ea_name, symbol, direction, lot_size, entry_price, sl, tp, rr, score, reason });
    res.json({ status: 'opened', trade_id: trade._id });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// POST /api/trading/trades/close
router.post('/close', async (req, res) => {
  const { ticket, ea_name, exit_price, profit, pips } = req.body;
  if (!ea_name) return res.status(400).json({ error: 'ea_name required' });
  try {
    const filter = ticket
      ? { ticket, ea_name, status: 'open' }
      : { ea_name, status: 'open' };
    const update = {
      exit_price, profit, pips,
      status:    'closed',
      closed_at: new Date()
    };
    await Trade.findOneAndUpdate(filter, update, { sort: { createdAt: -1 } });
    res.json({ status: 'closed', profit });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// GET /api/trading/trades/list
router.get('/list', async (req, res) => {
  const { ea_name, symbol, status, limit = 50 } = req.query;
  try {
    const filter = {};
    if (ea_name) filter.ea_name = ea_name;
    if (symbol)  filter.symbol  = symbol;
    if (status)  filter.status  = status;
    const trades = await Trade.find(filter).sort({ createdAt: -1 }).limit(parseInt(limit));
    res.json({ trades });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// GET /api/trading/trades/stats
router.get('/stats', async (req, res) => {
  const { ea_name } = req.query;
  try {
    const match = { status: 'closed' };
    if (ea_name) match.ea_name = ea_name;

    const stats = await Trade.aggregate([
      { $match: match },
      { $group: {
          _id:          '$ea_name',
          ea_name:      { $first: '$ea_name' },
          total_trades: { $sum: 1 },
          wins:         { $sum: { $cond: [{ $gte: ['$profit', 0] }, 1, 0] } },
          losses:       { $sum: { $cond: [{ $lt:  ['$profit', 0] }, 1, 0] } },
          total_profit: { $sum: '$profit' },
          avg_profit:   { $avg: '$profit' },
          avg_pips:     { $avg: '$pips' }
        }
      },
      { $addFields: {
          win_rate: {
            $round: [{ $multiply: [{ $divide: ['$wins', '$total_trades'] }, 100] }, 1]
          },
          total_profit: { $round: ['$total_profit', 2] },
          avg_profit:   { $round: ['$avg_profit',   2] },
          avg_pips:     { $round: ['$avg_pips',     1] }
        }
      },
      { $sort: { total_profit: -1 } }
    ]);
    res.json({ stats });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

module.exports = router;
