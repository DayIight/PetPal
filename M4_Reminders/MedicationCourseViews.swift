import SwiftUI

@MainActor struct MedicationCoursesView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    @State private var courses: [MedicationCourse] = []
    @State private var adding = false
    @State private var selected: MedicationCourse?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let store = MedicationCourseStore()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("记录主人已有的用药安排；每次实际服药需填写记录，也可明确跳过。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if courses.isEmpty { Text("还没有用药疗程，点「+」添加。").foregroundStyle(.secondary) }
                ForEach(courses) { course in
                    Button { selected = course } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(course.drugName).font(.headline); Spacer(); Text(statusText(course)).font(.caption) }
                            Text(course.times.map(\.label).joined(separator: "、")).monospacedDigit()
                            Text(course.startDate.formatted(date: .abbreviated, time: .omitted) + " 至 " + course.endDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("courses.row.\(course.id.uuidString)")
                }
            }
            .navigationTitle("\(pet.nickname)的用药疗程")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityIdentifier("courses.add") }
            }
            .sheet(isPresented: $adding, onDismiss: reload) { MedicationCourseFormView(pet: pet, service: service) }
            .sheet(item: $selected, onDismiss: reload) { MedicationCourseDetailView(pet: pet, initial: $0, service: service) }
            .onReceive(NotificationCenter.default.publisher(for: .careItemsDidChange)) { _ in reload() }
            .task { await service.rescheduleAll(); reload() }
        }
    }
    private func statusText(_ course: MedicationCourse) -> String {
        if course.status == .active && Calendar.current.startOfDay(for: Date()) > course.endDate { return "已到期" }
        return course.status.label
    }
    private func reload() {
        do { courses = try store.courses(petID: pet.id).sorted { $0.startDate > $1.startDate }; error = nil }
        catch { courses = []; self.error = "读取疗程失败：" + error.localizedDescription }
    }
}

@MainActor struct MedicationCourseFormView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    @State private var draft: MedicationCourse
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    init(pet: Pet, service: ReminderService, editing: MedicationCourse? = nil) {
        self.pet = pet; self.service = service; isNew = editing == nil
        let today = Calendar.current.startOfDay(for: Date())
        _draft = State(initialValue: editing ?? MedicationCourse(petID: pet.id, drugName: "", doseInstructions: "",
            startDate: today, endDate: today, times: [.init(hour: 8, minute: 0)]))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("主人填写的安排") {
                    TextField("药名（最多80字）", text: $draft.drugName).accessibilityIdentifier("course.drug")
                    TextField("单次用量／说明（最多500字）", text: $draft.doseInstructions, axis: .vertical)
                        .lineLimit(3...8).accessibilityIdentifier("course.instructions")
                    Text("按已有医嘱填写，App 不计算剂量或调整安排。完成时请另填实际用量。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("疗程日期（含首尾）") {
                    DatePicker("开始日期", selection: $draft.startDate, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                    DatePicker("结束日期", selection: $draft.endDate, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                    Text("最长180个日历日。编辑只影响后续待办，历史服药和跳过记录保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("每日时间（1至6个，不重复）") {
                    ForEach(draft.times.indices, id: \.self) { index in
                        HStack {
                            DatePicker("时间\(index + 1)", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                            if draft.times.count > 1 {
                                Button(role: .destructive) { draft.times.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("删除时间\(index + 1)")
                            }
                        }
                    }
                    if draft.times.count < 6 {
                        Button("添加时间") {
                            let occupied = Set(draft.times.map { $0.hour * 60 + $0.minute })
                            let minute = (0..<1440).first { !occupied.contains($0) } ?? 0
                            draft.times.append(.init(hour: minute / 60, minute: minute % 60))
                        }.accessibilityIdentifier("course.addTime")
                    }
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("course.error") }
                if busy { ProgressView("保存疗程与提醒…") }
            }
            .disabled(busy).navigationTitle(isNew ? "新增用药疗程" : "编辑用药疗程")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityIdentifier("course.save") }
            }
            .interactiveDismissDisabled(busy)
        }
    }
    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(get: {
            let time = draft.times[index]
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.times[index].hour = parts.hour ?? 8; draft.times[index].minute = parts.minute ?? 0
        })
    }
    private func save() {
        guard draft.petID == pet.id else { error = "当前宠物已变更，请重新打开。"; return }
        if let message = draft.validationError { error = message; return }
        busy = true; error = nil
        do {
            _ = try MedicationCourseStore().save(draft, petName: pet.nickname)
            Task {
                if draft.status == .active { await service.requestPermission() }
                await service.rescheduleAll(); busy = false; dismiss()
            }
        } catch { busy = false; self.error = "保存失败：" + error.localizedDescription }
    }
}

@MainActor struct MedicationCourseDetailView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    @State private var course: MedicationCourse
    @State private var records: [Record] = []
    @State private var editing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let store = MedicationCourseStore()
    init(pet: Pet, initial: MedicationCourse, service: ReminderService) {
        self.pet = pet; self.service = service; _course = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            List {
                Section("安排") {
                    Text(course.careCardSummary)
                    Text(course.status.label).foregroundStyle(.secondary)
                    Text(scheduleText).font(.footnote).foregroundStyle(.secondary)
                    if service.permission != .granted { Text("通知权限未开启；疗程已保存在设备上。").font(.footnote).foregroundStyle(.orange) }
                    if let error = error ?? service.scheduleError { Text(error).foregroundStyle(.red) }
                }
                if course.status != .ended {
                    Section("管理疗程") {
                        Button("编辑后续安排") { editing = true }
                        Button(course.status == .paused ? "恢复疗程" : "暂停疗程") { status(course.status == .paused ? .active : .paused) }
                        Button("结束疗程", role: .destructive) { status(.ended) }
                    }
                }
                Section("服药与跳过历史") {
                    if records.isEmpty { Text("暂无记录。请从今日待办记录实际服药或跳过。").foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        NavigationLink { RecordDetailView(record: record) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.answers["administrationStatus"] == "skipped" ? "已跳过（未服药）" : "实际服药记录")
                                Text(record.eventDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                Text(record.answers["dose"] ?? "").font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Button("删除疗程", role: .destructive) { deleting = true }
                    Text("删除后停止提醒；已有服药、跳过记录仍可在记录页查看。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(busy).navigationTitle(course.drugName)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $editing, onDismiss: reload) { MedicationCourseFormView(pet: pet, service: service, editing: course) }
            .confirmationDialog("删除此疗程并停止提醒？历史记录保留。", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除疗程", role: .destructive, action: remove)
            }
            .task { reload() }
        }
    }
    private var scheduleText: String {
        if course.status != .active { return "疗程已停止通知。历史记录保留。" }
        if Calendar.current.startOfDay(for: Date()) > course.endDate { return "已超过疗程结束日期，不再发送通知。" }
        let scheduled = course.times.compactMap { service.scheduledThrough[$0.reminderID] }
        if scheduled.count == course.times.count, let through = scheduled.min() {
            return "各时刻通知至少已安排至 " + through.formatted(date: .abbreviated, time: .shortened) + "。通知按最多64条滚动预排，请在截止前打开 App 补排。"
        }
        return "部分时刻尚未排入通知。通知按最多64条滚动预排，可返回提醒页重新安排。"
    }
    private func reload() {
        do {
            guard let latest = try store.courses(petID: pet.id).first(where: { $0.id == course.id }) else { dismiss(); return }
            course = latest; records = try store.history(for: latest); error = nil
        } catch { self.error = "读取失败：" + error.localizedDescription }
    }
    private func status(_ value: MedicationCourseStatus) {
        busy = true
        do {
            course = try store.setStatus(value, courseID: course.id, petID: pet.id)
            Task { if value == .active { await service.requestPermission() }; await service.rescheduleAll(); busy = false; reload() }
        } catch { busy = false; self.error = "修改失败：" + error.localizedDescription }
    }
    private func remove() {
        busy = true
        do {
            try store.delete(courseID: course.id, petID: pet.id)
            Task { await service.rescheduleAll(); busy = false; dismiss() }
        } catch { busy = false; self.error = "删除失败：" + error.localizedDescription }
    }
}

@MainActor struct MedicationCourseTaskView: View {
    let task: ReminderTask
    let course: MedicationCourse
    @ObservedObject var service: ReminderService
    @State private var recording = false
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            if recording {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(course.drugName) · 主人填写的安排：\(course.doseInstructions)")
                        .font(.footnote).padding().textSelection(.enabled)
                    PresetRecordFormView(completing: task)
                }
            } else {
                Form {
                    Section(course.drugName) {
                        Text("计划：" + task.due.formatted(date: .abbreviated, time: .shortened))
                        Text("主人填写的单次用量／说明：" + course.doseInstructions)
                        Text("请记录实际服药情况。跳过不会自动调整后续安排。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("填写实际服药记录") { recording = true }.accessibilityIdentifier("course.recordDose")
                    Button("跳过本次（未服药）", role: .destructive, action: skip).accessibilityIdentifier("course.skipDose")
                    if let error { Text(error).foregroundStyle(.red) }
                    if busy { ProgressView() }
                }
                .disabled(busy).navigationTitle("本次服药安排")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            }
        }
    }
    private func skip() {
        busy = true
        do {
            _ = try MedicationCourseStore().skip(task: task, courseID: course.id)
            Task { await service.rescheduleAll(); busy = false; dismiss() }
        } catch { busy = false; self.error = "跳过失败：" + error.localizedDescription }
    }
}
