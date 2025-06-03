require('dotenv').config();
const { ethers } = require('ethers');
const { address } = require('js-conflux-sdk');

async function main() {
    const privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) {
        console.error('No private key found in .env file');
        process.exit(1);
    }

    // Create an ethers wallet instance
    const wallet = new ethers.Wallet(privateKey);

    // Get Core Space address from private key
    const coreAddress = 'cfx:aam8xpwftb48rz47sjvzhgy8tyjp1peb86rgbzuey7';

    // Convert Core Space address to eSpace address
    const convertedESpaceAddress = address.cfxMappedEVMSpaceAddress(coreAddress);

    // Connect to eSpace mainnet
    const provider = new ethers.providers.JsonRpcProvider('https://evm.confluxrpc.com');
    const connectedWallet = wallet.connect(provider);

    // Get current gas price
    const gasPrice = await provider.getGasPrice();
    const gasPriceInCfx = ethers.utils.formatUnits(gasPrice, 'gwei');

    // Get balance
    const balance = await provider.getBalance(convertedESpaceAddress);
    const balanceInCfx = ethers.utils.formatEther(balance);

    console.log('\n=== Address Information ===');
    console.log('Core Space address:', coreAddress);
    console.log('Expected eSpace address:', convertedESpaceAddress);
    console.log('Current wallet eSpace address:', wallet.address);
    console.log('\nVerification:');
    console.log('Addresses match:', convertedESpaceAddress.toLowerCase() === wallet.address.toLowerCase());

    console.log('\n=== Balance and Gas Information ===');
    console.log('Current balance:', balanceInCfx, 'CFX');
    console.log('Current gas price:', gasPriceInCfx, 'Gwei');

    // Estimate gas costs for deployment
    const estimatedGasForDeploy = 5000000; // Rough estimate for contract deployment
    const estimatedGasForInit = 200000;    // Rough estimate for initialization
    const totalEstimatedGas = estimatedGasForDeploy + estimatedGasForInit;

    const estimatedCost = ethers.utils.formatEther(gasPrice.mul(totalEstimatedGas));
    console.log('\nEstimated deployment costs:');
    console.log('- Contract deployment:', ethers.utils.formatEther(gasPrice.mul(estimatedGasForDeploy)), 'CFX');
    console.log('- Initialization:', ethers.utils.formatEther(gasPrice.mul(estimatedGasForInit)), 'CFX');
    console.log('Total estimated cost:', estimatedCost, 'CFX');

    console.log('\n=== Links ===');
    console.log('Check balance at:');
    console.log(`https://evm.confluxscan.io/address/${convertedESpaceAddress}`);
    console.log('\nCheck Core Space balance at:');
    console.log(`https://confluxscan.io/address/${coreAddress}`);
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
}); 