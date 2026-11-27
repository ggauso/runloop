FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit
COPY public public
COPY db/*.sql db/
COPY server server
USER node
CMD ["node", "server/main.js"]
