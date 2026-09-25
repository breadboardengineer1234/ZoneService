local Signal = require(script.Parent.UsefulSignal)

export type Signal<T...> = Signal.Signal<T...>

export type Params = {
	Priority: number?,
	Dynamic: boolean?,
}

export type ZoneInfo = {
	Type: number,
	HalfSize: Vector3?,
	AxisAligned: boolean?,
	PosLower: Vector3,
	PosUpper: Vector3,

	Radius: number?,
	Radius2: number?,
	Height: number?,
	HalfHeight: number?,	

	CFrame: CFrame,
	InverseCFrame: CFrame?,
	Pos: Vector3,

	ZoneId: number,
	GroupId: number,
	Name: string,
	Group: string,
	Priority: number,
	Dynamic: boolean,
	
	EnteredSignal: Signal<Subject>?,
	ExitedSignal: Signal<Subject>?,
	Subjects: {[Subject]: boolean},
}

export type Subject = Player | Instance | {Position: Vector3}

export type SubjectInfo = {
	Type: number,
	Active: boolean,
	Char: Model?,
	RootPart: BasePart?,
	
	Candidates: {ZoneInfo},
	CurrZones: buffer,
	PrevZones: buffer,
	ChangedSignals: {[number]: Signal<string?>}
}

export type Shape = "Block" | "Ball" | "Cylinder"

export type Bucket = {[Subject]: SubjectInfo}

export type ZoneService = {
	addZone: (self: ZoneService, zoneName: string, group: string, cframe: CFrame, size: Vector3, shape: Shape,
		params: Params?) -> (),
	addZoneFromPart: (self: ZoneService, zoneName: string, group: string, part: BasePart, params: Params?) -> (),
	removeZone: (self: ZoneService, zoneName: string) -> (),
	
	ballSize: (radius: number) -> Vector3,
	cylinderSize: (radius: number, height: number) -> Vector3,
	
	updateZone: (self: ZoneService, zoneName: string, cframe: CFrame, size: Vector3) -> (),
	setPriority: (self: ZoneService, zoneName: string, priority: number) -> (),
	getZones: (self: ZoneService, subject: Subject) -> {string}?,
	
	track: (self: ZoneService, subject: Subject) -> (),
	untrack: (self: ZoneService, subject: Subject) -> (),
	
	changed: (subject: Subject, group: string, callback: (zoneName: string?) -> (), prefire: boolean?
	) -> Signal.Connection<string?>,
	entered: (zoneName: string, callback: (subject: Subject) -> ()) -> Signal.Connection<Subject>,
	exited: (zoneName: string, callback: (subject: Subject) -> ()) -> Signal.Connection<Subject>,
	
	getSubjectsInZoneFlags: (self: ZoneService, zoneName: string) -> {[Subject]: boolean}?,
	getZonesAtPoint: (self: ZoneService, point: Vector3) -> {string},
	isPointInZone: (self: ZoneService, point: Vector3, zoneName: string) -> boolean,
	getRandomPointInZone: (self: ZoneService, zoneName: string) -> Vector3?,
	
	rebuildBVH: (self: ZoneService) -> (),
	stopPoll: (self: ZoneService) -> (),
	startPoll: (self: ZoneService) -> (),
	destroy: (self: ZoneService) -> (),
}

return {}
