const mongoose = require('mongoose');

async function connectDB() {
  const uri = process.env.MONGO_URI || 'mongodb://localhost:27017/bmpt_trading';
  try {
    await mongoose.connect(uri);
    console.log('✅ MongoDB connected:', uri);
  } catch (err) {
    console.error('❌ MongoDB connection failed:', err.message);
    process.exit(1);
  }
}

mongoose.connection.on('disconnected', () => console.warn('⚠ MongoDB disconnected'));
mongoose.connection.on('reconnected',  () => console.log('✅ MongoDB reconnected'));

module.exports = { connectDB };
