const express   = require('express');
const router    = express.Router();
const Trade     = require('../models/Trade');
const Heartbeat = require('../models/Heartbeat');

router.get('/', async (req, res) => {
  try {
    const since     = new Date(Date.now() - 5 * 60 * 1000);
    const todayStart= new Date(); todayStart.setHours(0,0,0,0);

    const [openCount, aliveCount, todayTrades] = await Promise.all([
      Trade.countDocuments({ status: 'open' }),
      Heartbeat.distinct('ea_name', { createdAt: { $gte: since } }),
      Trade.find({ status: 'closed', closed_at: { $gte: todayStart } })
    ]);

    const todayWins   = todayTrades.filter(t => (t.profit || 0) >= 0).length;
    const todayLosses = todayTrades.filter(t => (t.profit || 0) <  0).length;
    const todayProfit = todayTrades.reduce((s, t) => s + (t.profit || 0), 0);

    res.json({
      server:       'BMPT Trading Server v1.0',
      db:           'MongoDB',
      time:         new Date().toISOString(),
      open_trades:  openCount,
      alive_eas:    aliveCount.length,
      today_wins:   todayWins,
      today_losses: todayLosses,
      today_profit: Math.round(todayProfit * 100) / 100
    });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

module.exports = router;
