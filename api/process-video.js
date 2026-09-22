// file: api/process-video.js
const { YoutubeTranscript } = require('youtube-transcript');

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*'); 
  
  const videoId = req.query.id; 
  if (!videoId) {
    return res.status(400).json({ error: 'Thiếu ID video' });
  }
  
  try {
    // Ép lấy phụ đề tiếng Anh (ưu tiên CC, nếu không có thì lấy auto)
    const transcript = await YoutubeTranscript.fetchTranscript(videoId, { lang: 'en' });
    
    const processedData = transcript.map(item => ({
      text: item.text.replace(/&amp;/g, '&').replace(/&#39;/g, "'").replace(/&quot;/g, '"'), // Dọn dẹp mấy ký tự html lỗi
      offset: item.offset,     
      duration: item.duration, 
      vi_translation: "Bản dịch tiếng Việt đang cập nhật...", 
      ipa: "" 
    }));

    res.status(200).json(processedData);
  } catch (error) {
    // Nếu vẫn lỗi thì báo ra
    res.status(500).json({ error: 'Không lấy được phụ đề', details: error.message });
  }
}
