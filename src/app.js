require('dotenv').config();
const express    = require('express');
const cors       = require('cors');
const helmet     = require('helmet');
const morgan     = require('morgan');
const { connectDB } = require('./models/db');

const eaRoutes      = require('./routes/ea');
const tradeRoutes   = require('./routes/trades');
const signalRoutes  = require('./routes/signals');
const statusRoutes  = require('./routes/status');
const dashRoutes    = require('./routes/dashboard');

const app     = express();
const PORT    = process.env.PORT    || 3000;
const API_KEY = process.env.API_KEY || 'bmpt-secret-key-change-this';

app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json());

// Auth middleware for all /api routes
app.use('/api', (req, res, next) => {
  const key = req.headers['x-api-key'] || req.query.apikey;
  if (key !== API_KEY) return res.status(401).json({ error: 'Unauthorised' });
  next();
});

app.use('/api/ea',        eaRoutes);
app.use('/api/trades',    tradeRoutes);
app.use('/api/signals',   signalRoutes);
app.use('/api/status',    statusRoutes);
app.use('/api/dashboard', dashRoutes);

app.get('/health', (req, res) => res.json({
  status: 'ok',
  db:     'mongodb',
  time:   new Date().toISOString(),
  server: 'BMPT Trading Server v1.0'
}));

app.get('/', (req, res) => res.json({
  name: 'BMPT Trading Server',
  db:   'MongoDB + Mongoose',
  routes: [
    'GET  /health',
    'POST /api/ea/heartbeat',
    'POST /api/ea/signal',
    'POST /api/trades/open',
    'POST /api/trades/close',
    'GET  /api/trades/list',
    'GET  /api/trades/stats',
    'GET  /api/signals/latest',
    'GET  /api/status',
    'GET  /api/dashboard'
  ]
}));

// Connect to MongoDB then start server
connectDB().then(() => {
  app.listen(PORT, '127.0.0.1', () => {
    console.log(`\n✅ BMPT Trading Server on port ${PORT}`);
    console.log(`   DB: ${process.env.MONGO_URI}`);
    console.log(`   Health: http://localhost:${PORT}/health\n`);
  });
});

module.exports = app;




