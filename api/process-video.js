// file: api/process-video.js (Deploy lên Vercel)
const { YoutubeTranscript } = require('youtube-transcript');

module.exports = async function handler(req, res) {
  // Bật CORS cho phép GitHub Pages gọi vào
  res.setHeader('Access-Control-Allow-Origin', '*'); 
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  // Xử lý các yêu cầu Preflight OPTIONS từ trình duyệt
  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }
  
  const videoId = req.query.id; // Lấy ID video từ URL

  if (!videoId) {
    return res.status(400).json({ error: 'Thiếu tham số id của video' });
  }
  
  try {
    // Kéo phụ đề từ YouTube không lo CORS
    const transcript = await YoutubeTranscript.fetchTranscript(videoId);
    
    // Tạo cấu trúc data trả về theo yêu cầu của bạn:
    const processedData = transcript.map(item => ({
      text: item.text,
      offset: item.offset,     // Thời gian bắt đầu (miligiây)
      duration: item.duration, // Thời lượng câu
      vi_translation: "Bản dịch tiếng Việt sẽ nằm ở đây...", // Chờ gọi API dịch
      ipa: "/ipa/ sẽ nằm ở đây/" // Chờ hàm tạo IPA
    }));

    // Trả cục data về cho frontend
    res.status(200).json(processedData);
  } catch (error) {
    res.status(500).json({ error: 'Không lấy được phụ đề' });
  }
}
