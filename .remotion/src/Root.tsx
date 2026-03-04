import "./index.css";
import { Composition } from "remotion";
import { DevSwarm } from "./Composition";

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="DevSwarm"
      component={DevSwarm}
      durationInFrames={660}
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
