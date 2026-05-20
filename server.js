const express = require('express');
const path = require('path');
require('dotenv').config();

const db = require('./db');
const apiRoutes = require('./routes/api');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'home.html'));
});

app.use(express.static(path.join(__dirname, 'public'), { index: false }));

app.use('/api', apiRoutes);

app.get('/gestion', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'gestion.html'));
});

app.get('/picker', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'picker.html'));
});

async function start() {
    await db.connect();
    app.listen(PORT, () => {
        console.log(`Picking por Producto running on http://localhost:${PORT}`);
    });
}

start().catch(console.error);
