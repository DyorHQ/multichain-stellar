-- Moments media: a Moment's NFT can be a photo or a video. The public launch-media bucket accepts video files
-- (MP4 / QuickTime) up to 50 MB next to images; the app writes the poster frame as the NFT image and the video as
-- its animation_url.
update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime']
 where id = 'launch-media';
