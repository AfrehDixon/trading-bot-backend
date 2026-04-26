const express   = require('express');
const router    = express.Router();
const Heartbeat = require('../models/Heartbeat');
const Signal    = require('../models/Signal');

// POST /api/ea/heartbeat
router.post('/heartbeat', async (req, res) => {
  const { ea_name, symbol, timeframe, account_id, balance, equity, message } = req.body;
  if (!ea_name || !symbol) return res.status(400).json({ error: 'ea_name and symbol required' });
  try {
    await Heartbeat.create({ ea_name, symbol, timeframe, account_id, balance, equity, message });
    res.json({ status: 'alive', server: 'BMPT', timestamp: new Date().toISOString(), command: 'none' });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// POST /api/ea/signal
router.post('/signal', async (req, res) => {
  const { ea_name, symbol, direction, score, pattern, reason, entry, sl, tp, rr } = req.body;
  if (!ea_name || !symbol || !direction) return res.status(400).json({ error: 'ea_name, symbol, direction required' });
  try {
    const sig = await Signal.create({ ea_name, symbol, direction, score, pattern, reason, entry, sl, tp, rr });
    res.json({ status: 'recorded', signal_id: sig._id, message: `${direction} signal on ${symbol} logged` });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// GET /api/ea/alive — EAs active in last 5 minutes
router.get('/alive', async (req, res) => {
  try {
    const since = new Date(Date.now() - 5 * 60 * 1000);
    const eas   = await Heartbeat.aggregate([
      { $match: { createdAt: { $gte: since } } },
      { $sort:  { createdAt: -1 } },
      { $group: {
          _id:       { ea_name: '$ea_name', symbol: '$symbol' },
          ea_name:   { $first: '$ea_name' },
          symbol:    { $first: '$symbol' },
          timeframe: { $first: '$timeframe' },
          balance:   { $first: '$balance' },
          equity:    { $first: '$equity' },
          message:   { $first: '$message' },
          last_seen: { $max:   '$createdAt' }
        }
      },
      { $sort: { last_seen: -1 } }
    ]);
    res.json({ alive: eas.length, eas });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

module.exports = router;
