# ---------- Build Stage ----------
    FROM node:16 as builder

    WORKDIR /app/interface
    
    # Copy package files first for layer caching
    COPY interface/package*.json ./
    
    RUN npm install
    
    # Copy frontend source including craco.config.js
    COPY interface/ ./
    
    # Copy ABI files where the frontend expects them
    COPY contract /app/contract
    
    # Build the frontend
    RUN npm run build
    
    # ---------- Production Stage ----------
    FROM node:16-slim as production
    
    WORKDIR /app
    
    RUN npm install -g serve
    
    COPY --from=builder /app/interface/build ./build
    
    EXPOSE 3000
    CMD ["serve", "-s", "build", "-l", "3000"]
    