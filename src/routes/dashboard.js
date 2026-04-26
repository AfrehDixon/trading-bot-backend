const express   = require('express');
const router    = express.Router();
const Trade     = require('../models/Trade');
const Signal    = require('../models/Signal');
const Heartbeat = require('../models/Heartbeat');

router.get('/', async (req, res) => {
  try {
    const since5m    = new Date(Date.now() - 5 * 60 * 1000);
    const since7d    = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
    const todayStart = new Date(); todayStart.setHours(0,0,0,0);

    const [overall, perEA, last7Days, openTrades, recentClosed, aliveEAs] = await Promise.all([

      // Overall stats
      Trade.aggregate([
        { $match: { status: 'closed' } },
        { $group: {
            _id:          null,
            total:        { $sum: 1 },
            wins:         { $sum: { $cond: [{ $gte: ['$profit', 0] }, 1, 0] } },
            losses:       { $sum: { $cond: [{ $lt:  ['$profit', 0] }, 1, 0] } },
            total_profit: { $sum: '$profit' },
            avg_profit:   { $avg: '$profit' },
            avg_pips:     { $avg: '$pips' }
          }
        },
        { $addFields: {
            win_rate:     { $round: [{ $multiply: [{ $divide: ['$wins', '$total'] }, 100] }, 1] },
            total_profit: { $round: ['$total_profit', 2] },
            avg_profit:   { $round: ['$avg_profit', 2] },
            avg_pips:     { $round: ['$avg_pips', 1] }
          }
        }
      ]),

      // Per EA stats
      Trade.aggregate([
        { $match: { status: 'closed' } },
        { $group: {
            _id:     '$ea_name',
            ea_name: { $first: '$ea_name' },
            trades:  { $sum: 1 },
            wins:    { $sum: { $cond: [{ $gte: ['$profit', 0] }, 1, 0] } },
            profit:  { $sum: '$profit' }
          }
        },
        { $addFields: {
            win_rate: { $round: [{ $multiply: [{ $divide: ['$wins', '$trades'] }, 100] }, 1] },
            profit:   { $round: ['$profit', 2] }
          }
        },
        { $sort: { profit: -1 } }
      ]),

      // Last 7 days daily breakdown
      Trade.aggregate([
        { $match: { status: 'closed', closed_at: { $gte: since7d } } },
        { $group: {
            _id:    { $dateToString: { format: '%Y-%m-%d', date: '$closed_at' } },
            date:   { $first: { $dateToString: { format: '%Y-%m-%d', date: '$closed_at' } } },
            wins:   { $sum: { $cond: [{ $gte: ['$profit', 0] }, 1, 0] } },
            losses: { $sum: { $cond: [{ $lt:  ['$profit', 0] }, 1, 0] } },
            profit: { $sum: '$profit' }
          }
        },
        { $addFields: { profit: { $round: ['$profit', 2] } } },
        { $sort: { date: -1 } }
      ]),

      // Open trades
      Trade.find({ status: 'open' }).sort({ createdAt: -1 }).limit(20),

      // Recent closed
      Trade.find({ status: 'closed' }).sort({ closed_at: -1 }).limit(10),

      // Alive EAs
      Heartbeat.aggregate([
        { $match: { createdAt: { $gte: since5m } } },
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
        }
      ])
    ]);

    res.json({
      generated_at:  new Date().toISOString(),
      overall:       overall[0] || { total:0, wins:0, losses:0, total_profit:0, win_rate:0 },
      per_ea:        perEA,
      last_7_days:   last7Days,
      open_trades:   openTrades,
      recent_closed: recentClosed,
      alive_eas:     aliveEAs
    });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

module.exports = router;
