const sharp = require('sharp');
const fs = require('fs/promises');
const path = require('path');

// iOS icon sizes required for different devices and situations
const iconSizes = {
    // App Store
    'iTunesArtwork@2x.png': 1024,
    
    // iPhone
    'iPhone_20@2x.png': 40,
    'iPhone_20@3x.png': 60,
    'iPhone_29@2x.png': 58,
    'iPhone_29@3x.png': 87,
    'iPhone_40@2x.png': 80,
    'iPhone_40@3x.png': 120,
    'iPhone_60@2x.png': 120,
    'iPhone_60@3x.png': 180,
    
    // iPad
    'iPad_20.png': 20,
    'iPad_20@2x.png': 40,
    'iPad_29.png': 29,
    'iPad_29@2x.png': 58,
    'iPad_40.png': 40,
    'iPad_40@2x.png': 80,
    'iPad_76.png': 76,
    'iPad_76@2x.png': 152,
    'iPad_83.5@2x.png': 167,
    
    // Settings & Spotlight
    'settings_29.png': 29,
    'settings_29@2x.png': 58,
    'settings_29@3x.png': 87,
    'spotlight_40.png': 40,
    'spotlight_40@2x.png': 80,
    'spotlight_40@3x.png': 120,
};

async function generateIcons(inputImagePath, outputDir) {
    try {
        // Create output directory if it doesn't exist
        await fs.mkdir(outputDir, { recursive: true });
        
        // Load the input image
        const image = sharp(inputImagePath);
        
        // Get image metadata to verify input image size
        const metadata = await image.metadata();
        
        // Check if input image is large enough
        if (metadata.width < 1024 || metadata.height < 1024) {
            throw new Error('Input image must be at least 1024x1024 pixels');
        }
        
        // Generate each icon size
        const generations = Object.entries(iconSizes).map(async ([filename, size]) => {
            const outputPath = path.join(outputDir, filename);
            
            try {
                await image
                    .resize(size, size, {
                        fit: 'contain',
                        background: { r: 0, g: 0, b: 0, alpha: 0 }
                    })
                    .toFile(outputPath);
                
                console.log(`Generated: ${filename} (${size}x${size})`);
            } catch (err) {
                console.error(`Error generating ${filename}: ${err.message}`);
            }
        });
        
        // Wait for all icons to be generated
        await Promise.all(generations);
        
        // Generate Contents.json
        const contentsJson = generateContentsJson();
        await fs.writeFile(
            path.join(outputDir, 'Contents.json'),
            JSON.stringify(contentsJson, null, 2)
        );
        
        console.log('\nIcon generation complete!');
        console.log(`Icons saved to: ${outputDir}`);
        
    } catch (err) {
        console.error('Error:', err.message);
        process.exit(1);
    }
}

function generateContentsJson() {
    return {
        "images": [
            {
                "size": "20x20",
                "idiom": "iphone",
                "filename": "iPhone_20@2x.png",
                "scale": "2x"
            },
            {
                "size": "20x20",
                "idiom": "iphone",
                "filename": "iPhone_20@3x.png",
                "scale": "3x"
            },
            // Add more image entries as needed
        ],
        "info": {
            "version": 1,
            "author": "JS+FluxPro"
        }
    };
}

// Example usage
const inputImage = 'replicate-prediction1.png';  // Your source image (at least 1024x1024)
const outputDirectory = '../AudioScratchSpace/Assets.xcassets/AppIcon.appiconset';

generateIcons(inputImage, outputDirectory);