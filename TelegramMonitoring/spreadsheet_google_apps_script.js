function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);
    var kategori = data.kategori || "INFO";
    var pesan = data.pesan || "Tidak ada pesan";
    
    // Konversi sisa %0A dari skrip lama OpenWrt menjadi baris baru (newline) yang benar
    pesan = pesan.replace(/%0A/g, '\n').replace(/\\n/g, '\n');
    
    // Merakit format pesan akhir sesuai permintaan Anda
    var formatPesan = "*" + kategori + "*\n\n" + pesan;
    
    // Simpan ke Spreadsheet
    var sheet = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
    var timestamp = new Date();
    sheet.appendRow([timestamp, kategori, pesan]);
    
    // Kirim ke Telegram
    var token = ""; // Pastikan token Anda benar
    var chatId = "";  // Pastikan chat ID Anda benar
    var telegramUrl = "https://api.telegram.org/bot" + token + "/sendMessage";
    
    var payload = {
      "chat_id": chatId,
      "text": formatPesan,
      "parse_mode": "Markdown"
    };
    
    var options = {
      "method": "post",
      "contentType": "application/json",
      "payload": JSON.stringify(payload)
    };
    
    UrlFetchApp.fetch(telegramUrl, options);
    
    return ContentService.createTextOutput(JSON.stringify({"status": "success"})).setMimeType(ContentService.MimeType.JSON);
    
  } catch(error) {
    return ContentService.createTextOutput(JSON.stringify({"status": "error", "message": error.toString()})).setMimeType(ContentService.MimeType.JSON);
  }
}

function hapusLogLama() {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
  var data = sheet.getDataRange().getValues();
  var batasWaktu = new Date();
  batasWaktu.setDate(batasWaktu.getDate() - 30);
  
  for (var i = data.length - 1; i > 0; i--) {
    var tanggalBaris = new Date(data[i][0]);
    if (tanggalBaris < batasWaktu) {
      sheet.deleteRow(i + 1);
    }
  }
}