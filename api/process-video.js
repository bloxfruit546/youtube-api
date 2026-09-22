export default async function handler(req, res) {
  // Mở khóa CORS cho web giao diện của mày truy cập
  res.setHeader('Access-Control-Allow-Origin', '*'); 
  
  const videoId = req.query.id; 
  if (!videoId) {
    return res.status(400).json({ error: 'Thiếu ID video' });
  }
  
  try {
    // 1. Kho áo khoác ngụy trang (Fake User-Agents)
    const userAgents = [
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/113.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/113.0'
    ];
    const randomUA = userAgents[Math.floor(Math.random() * userAgents.length)];

    // 2. Lẻn vào YouTube lấy link chứa dữ liệu phụ đề
    const ytResponse = await fetch(`https://www.youtube.com/watch?v=${videoId}`, {
      headers: {
        'User-Agent': randomUA,
        'Accept-Language': 'en-US,en;q=0.9',
      }
    });
    const html = await ytResponse.text();

    // Dùng Regex tìm file phụ đề ẩn trong mã nguồn YouTube
    const captionRegex = /"captionTracks":\[(.*?)\]/;
    const match = captionRegex.exec(html);

    if (!match) throw new Error("Video này hoàn toàn không có file phụ đề nào.");

    const tracks = JSON.parse(`[${match[1]}]`);
    
    // Ưu tiên phụ đề tiếng Anh (en) tự tay người dùng up, nếu không có thì lấy cái AI tự động
    let track = tracks.find(t => t.languageCode === 'en' && t.kind !== 'asr');
    if (!track) track = tracks.find(t => t.languageCode === 'en');
    if (!track) track = tracks[0];

    // 3. Tải file XML phụ đề về
    const xmlResponse = await fetch(track.baseUrl);
    const xmlText = await xmlResponse.text();

    // 4. Dịch mã XML sang định dạng JSON cho web của mày đọc
    const textRegex = /<text start="([\d.]+)" dur="([\d.]+)"[^>]*>(.*?)<\/text>/g;
    let processedData = [];
    let textMatch;

    while ((textMatch = textRegex.exec(xmlText)) !== null) {
        let text = textMatch[3]
            .replace(/&amp;/g, '&')
            .replace(/&#39;/g, "'")
            .replace(/&quot;/g, '"');
        text = text.replace(/<[^>]*>?/gm, ''); // Lọc sạch rác code thừa

        processedData.push({
            offset: parseFloat(textMatch[1]) * 1000,
            duration: parseFloat(textMatch[2]) * 1000,
            text: text,
            vi_translation: "Bản dịch đang được xử lý...",
            ipa: ""
        });
    }

    if (processedData.length === 0) throw new Error("Trích xuất phụ đề thất bại.");

    // Gửi cục hàng xịn về cho web giao diện
    res.status(200).json(processedData);
    
  } catch (error) {
    res.status(500).json({ error: 'Lỗi cào dữ liệu', details: error.message });
  }
}
