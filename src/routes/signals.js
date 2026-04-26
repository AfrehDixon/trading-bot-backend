const express = require('express');
const router  = express.Router();
const Signal  = require('../models/Signal');

router.get('/latest', async (req, res) => {
  const { symbol, limit = 20 } = req.query;
  try {
    const filter = {};
    if (symbol) filter.symbol = symbol;
    const signals = await Signal.find(filter).sort({ createdAt: -1 }).limit(parseInt(limit));
    res.json({ signals });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

module.exports = router;
