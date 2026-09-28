local Signal = require(script.Parent.UsefulSignal)

export type Signal<T...> = Signal.Signal<T...>

export type Shape = string | "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

export type Params = {
	Priority: number?,
	Dynamic: boolean?,
}

export type Tree = {
	nodeCount: number,
	nextNode: number,
	nodeMin: buffer,
	nodeMax: buffer,
	nodeSkip: buffer,
	nodeZone: {ZoneInfo},

	orderedZones: {ZoneInfo},
	mortonCodes: {number},

	minBound: vector,
	maxBound: vector,
	prevNodeCount: number,

	build: (self: Tree, zones: {[string]: ZoneInfo}, numZones: number) -> (),
	query: (self: Tree, pos: Vector3, results: {ZoneInfo}) -> (),
	updateBounds: (self: Tree, min: Vector3, max: Vector3) -> (),
	setBounds: (self: Tree, min: vector, max: vector) -> (),
	reset: (self: Tree) -> (),
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
	Slope: number?,
	SlopeX: number?,
	SlopeZ: number?,
	
	Size: Vector3,
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

export type Subject = Player | Model | {Position: Vector3}

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

export type Bucket = {[Subject]: SubjectInfo}

return nil
