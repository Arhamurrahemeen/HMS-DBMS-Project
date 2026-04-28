-- Create the HSK Bone Care database
CREATE DATABASE hsk_bone_care;

-- Verify it exists
SELECT datname FROM pg_database WHERE datname = 'hsk_bone_care';