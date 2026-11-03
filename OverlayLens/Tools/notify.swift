// ส่ง distributed notification ให้ StampLab — ใช้ทดสอบหน้าจอพักจาก Terminal
//   swift Tools/notify.swift ambientIdleTest   # ย่อเวลารอเป็น 15 วิ แล้วปล่อยมือ
//   swift Tools/notify.swift ambientPreview    # ดูตัวอย่างทันที
//   swift Tools/notify.swift ambientRecap      # ดูการ์ดสรุปตอนกลับมา
import Foundation

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ambientPreview"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.stamp.StampLab.\(name)"),
    object: nil, userInfo: nil, deliverImmediately: true)
print("posted com.stamp.StampLab.\(name)")
