FROM node:18-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package.json package-lock.json* ./
RUN npm install

# Copy source
COPY . .

# Production uses "start", dev uses "dev" (nodemon) via devspace command override
CMD ["npm", "start"]